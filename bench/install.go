package main

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"regexp"

	"github.com/jackc/pgx/v5"
)

type extension struct {
	name    string
	version string
	comment string
	script  string
}

var controlLine = regexp.MustCompile(`(?m)^\s*(\w+)\s*=\s*'(.*)'\s*$`)

// loadExtension reads pgledger.control and its versioned script from dir, or from the nearest
// ancestor of the working directory that holds the control file.
func loadExtension(dir string) (*extension, error) {
	if dir == "" {
		wd, err := os.Getwd()
		if err != nil {
			return nil, err
		}
		for d := wd; ; d = filepath.Dir(d) {
			if _, err := os.Stat(filepath.Join(d, "pgledger.control")); err == nil {
				dir = d
				break
			}
			if filepath.Dir(d) == d {
				return nil, fmt.Errorf("pgledger.control not found above %s; pass -ext-dir", wd)
			}
		}
	}
	ctl, err := os.ReadFile(filepath.Join(dir, "pgledger.control"))
	if err != nil {
		return nil, err
	}
	ext := &extension{name: "pgledger"}
	for _, m := range controlLine.FindAllStringSubmatch(string(ctl), -1) {
		switch m[1] {
		case "default_version":
			ext.version = m[2]
		case "comment":
			ext.comment = m[2]
		}
	}
	if ext.version == "" {
		return nil, fmt.Errorf("%s: no default_version", filepath.Join(dir, "pgledger.control"))
	}
	script, err := os.ReadFile(filepath.Join(dir, fmt.Sprintf("pgledger--%s.sql", ext.version)))
	if err != nil {
		return nil, err
	}
	ext.script = string(script)
	return ext, nil
}

// installExtension drops any previous pgledger and registers the working-tree script through
// pg_tle, the same route supabase/migrations uses. Tables are append-only, so a reinstall is the
// only way to start from an empty ledger.
func installExtension(ctx context.Context, conn *pgx.Conn, ext *extension, schema string) error {
	q := pgx.Identifier{schema}.Sanitize()
	steps := []struct {
		sql  string
		args []any
	}{
		{"CREATE EXTENSION IF NOT EXISTS pg_tle", nil},
		{"DROP EXTENSION IF EXISTS pgledger CASCADE", nil},
		{"DROP SCHEMA IF EXISTS " + q + " CASCADE", nil},
		{"SELECT pgtle.uninstall_extension_if_exists($1)", []any{ext.name}},
		{"SELECT pgtle.install_extension($1, $2, $3, $4, '{}'::text[])", []any{ext.name, ext.version, ext.comment, ext.script}},
		{"SELECT pgtle.set_default_version($1, $2)", []any{ext.name, ext.version}},
		{"CREATE SCHEMA " + q, nil},
		{"CREATE EXTENSION pgledger SCHEMA " + q, nil},
	}
	for _, s := range steps {
		if _, err := conn.Exec(ctx, s.sql, s.args...); err != nil {
			return fmt.Errorf("%s: %w", s.sql, err)
		}
	}
	return nil
}
