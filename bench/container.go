package main

import (
	"bytes"
	"context"
	"fmt"
	"log"
	"os/exec"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
)

const containerPassword = "postgres"

type container struct {
	name string
	port int
}

// dsn is the connection the benchmark uses: the postgres role, as the Supabase CLI sets it up.
func (c *container) dsn() string {
	return fmt.Sprintf("postgres://postgres:%s@127.0.0.1:%d/postgres", containerPassword, c.port)
}

// adminDSN is the image's bootstrap superuser, used once to mirror the CLI's boot script.
func (c *container) adminDSN() string {
	return fmt.Sprintf("postgres://supabase_admin:%s@127.0.0.1:%d/postgres", containerPassword, c.port)
}

func docker(ctx context.Context, args ...string) (string, error) {
	cmd := exec.CommandContext(ctx, "docker", args...)
	var out, errb bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &errb
	if err := cmd.Run(); err != nil {
		return "", fmt.Errorf("docker %s: %w: %s", args[0], err, strings.TrimSpace(errb.String()))
	}
	return strings.TrimSpace(out.String()), nil
}

// ensureContainer starts the postgres container, or reuses one left by -keep, then applies the
// same bootstrap the Supabase CLI does on boot so the postgres role can log in and use pg_tle.
func ensureContainer(ctx context.Context, cfg *config) (*container, error) {
	c := &container{name: cfg.name, port: cfg.port}

	state, err := docker(ctx, "inspect", "-f", "{{.State.Running}}", cfg.name)
	switch {
	case err == nil && state == "true":
		log.Printf("reusing running container %s", cfg.name)
	case err == nil:
		log.Printf("starting stopped container %s", cfg.name)
		if _, err := docker(ctx, "start", cfg.name); err != nil {
			return nil, err
		}
	default:
		args := []string{"run", "-d", "--name", cfg.name,
			"-p", fmt.Sprintf("%d:5432", cfg.port),
			"-e", "POSTGRES_PASSWORD=" + containerPassword,
			cfg.image}
		if len(cfg.pgOpts) > 0 {
			// The image's CMD is `postgres -D /etc/postgresql`; extend it with -c settings.
			args = append(args, "postgres", "-D", "/etc/postgresql")
			for _, kv := range cfg.pgOpts {
				args = append(args, "-c", kv)
			}
		}
		log.Printf("starting container %s from %s on port %d", cfg.name, cfg.image, cfg.port)
		if _, err := docker(ctx, args...); err != nil {
			return nil, err
		}
	}

	admin, err := c.waitReady(ctx, 2*time.Minute)
	if err != nil {
		if !cfg.keep {
			c.remove()
		}
		return nil, err
	}
	defer admin.Close(context.Background())

	for _, q := range []string{
		"ALTER USER postgres WITH PASSWORD '" + containerPassword + "'",
		"CREATE EXTENSION IF NOT EXISTS pg_tle",
		"GRANT pgtle_admin TO postgres",
	} {
		if _, err := admin.Exec(ctx, q); err != nil {
			return nil, fmt.Errorf("bootstrap %q: %w", q, err)
		}
	}
	return c, nil
}

func (c *container) waitReady(ctx context.Context, timeout time.Duration) (*pgx.Conn, error) {
	deadline := time.Now().Add(timeout)
	var last error
	for time.Now().Before(deadline) {
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		conn, err := pgx.Connect(ctx, c.adminDSN())
		if err == nil {
			return conn, nil
		}
		last = err
		if state, ierr := docker(ctx, "inspect", "-f", "{{.State.Running}}", c.name); ierr == nil && state != "true" {
			logs, _ := docker(ctx, "logs", "--tail", "20", c.name)
			return nil, fmt.Errorf("container %s exited during startup:\n%s", c.name, logs)
		}
		time.Sleep(500 * time.Millisecond)
	}
	return nil, fmt.Errorf("container %s not ready after %s: %v", c.name, timeout, last)
}

func (c *container) remove() {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	log.Printf("removing container %s", c.name)
	if _, err := docker(ctx, "rm", "-f", "-v", c.name); err != nil {
		log.Printf("warning: %v", err)
	}
}
