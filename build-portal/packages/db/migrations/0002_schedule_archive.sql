ALTER TABLE schedules ADD COLUMN IF NOT EXISTS archived_at timestamptz;
CREATE INDEX IF NOT EXISTS schedules_active_idx ON schedules(enabled, archived_at, created_at DESC);
