-- pg_tle is how the playground installs pgledger: the extension script is registered from a
-- string rather than read out of the server's extension directory, which is the only route
-- available on a managed provider.
CREATE EXTENSION IF NOT EXISTS pg_tle;
