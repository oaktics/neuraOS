BEGIN;
CREATE TABLE IF NOT EXISTS neura_workspaces (
  id uuid PRIMARY KEY,
  owner_id text NOT NULL,
  revision bigint NOT NULL DEFAULT 0,
  state jsonb NOT NULL CHECK (state->>'schemaVersion' = '1'),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS neura_workspace_owner ON neura_workspaces(owner_id);
CREATE TABLE IF NOT EXISTS neura_audit (
  id uuid PRIMARY KEY,
  workspace_id uuid NOT NULL REFERENCES neura_workspaces(id),
  actor text NOT NULL, operation text NOT NULL, target text NOT NULL,
  trace_id uuid NOT NULL, recorded_at timestamptz NOT NULL
);
CREATE TABLE IF NOT EXISTS neura_memory_search (
  id uuid PRIMARY KEY, workspace_id uuid NOT NULL REFERENCES neura_workspaces(id),
  content text NOT NULL,
  search tsvector GENERATED ALWAYS AS (to_tsvector('simple',content)) STORED
);
CREATE INDEX IF NOT EXISTS neura_memory_fts ON neura_memory_search USING gin(search);
CREATE TABLE IF NOT EXISTS neura_deletions (
  workspace_id uuid NOT NULL REFERENCES neura_workspaces(id), memory_id uuid NOT NULL,
  deleted_at timestamptz NOT NULL, PRIMARY KEY(workspace_id,memory_id)
);
ALTER TABLE neura_workspaces ENABLE ROW LEVEL SECURITY;
ALTER TABLE neura_workspaces FORCE ROW LEVEL SECURITY;
ALTER TABLE neura_audit ENABLE ROW LEVEL SECURITY;
ALTER TABLE neura_audit FORCE ROW LEVEL SECURITY;
ALTER TABLE neura_memory_search ENABLE ROW LEVEL SECURITY;
ALTER TABLE neura_memory_search FORCE ROW LEVEL SECURITY;
ALTER TABLE neura_deletions ENABLE ROW LEVEL SECURITY;
ALTER TABLE neura_deletions FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS workspace_owner ON neura_workspaces;
CREATE POLICY workspace_owner ON neura_workspaces USING (owner_id = current_setting('neura.user_id',true)) WITH CHECK(owner_id = current_setting('neura.user_id',true));
DROP POLICY IF EXISTS audit_owner ON neura_audit;
CREATE POLICY audit_owner ON neura_audit USING (EXISTS(SELECT 1 FROM neura_workspaces w WHERE w.id=workspace_id));
DROP POLICY IF EXISTS memory_owner ON neura_memory_search;
CREATE POLICY memory_owner ON neura_memory_search USING (EXISTS(SELECT 1 FROM neura_workspaces w WHERE w.id=workspace_id));
DROP POLICY IF EXISTS deletion_owner ON neura_deletions;
CREATE POLICY deletion_owner ON neura_deletions USING (EXISTS(SELECT 1 FROM neura_workspaces w WHERE w.id=workspace_id));
COMMIT;
