CREATE TABLE IF NOT EXISTS user (
  id INTEGER PRIMARY KEY,
  display_name TEXT NOT NULL,

  CONSTRAINT user_display_name_not_empty
    CHECK (length(display_name) > 0)
) STRICT;

CREATE TABLE IF NOT EXISTS checklist (
  id INTEGER PRIMARY KEY,
  title TEXT NOT NULL,
  created_by_user_id INTEGER NOT NULL,
  created_on_timestamp TEXT NOT NULL, -- ISO8601

  CONSTRAINT checklist_created_by_user_id_foreign_key
    FOREIGN KEY (created_by_user_id) REFERENCES user (id)
    ON DELETE RESTRICT,

  CONSTRAINT checklist_created_on_timestamp_iso8601_format
    CHECK (datetime(created_on_timestamp) = created_on_timestamp)
) STRICT;

CREATE TABLE IF NOT EXISTS item (
  id INTEGER PRIMARY KEY,
  parent_checklist_id INTEGER NOT NULL,
  title TEXT NOT NULL,
  created_by_user_id INTEGER NOT NULL,
  created_on_timestamp TEXT NOT NULL, -- ISO8601

  CONSTRAINT item_parent_checklist_id_foreign_key
    FOREIGN KEY (parent_checklist_id) REFERENCES checklist (id)
    ON DELETE CASCADE,

  CONSTRAINT item_created_by_user_id_foreign_key
    FOREIGN KEY (created_by_user_id) REFERENCES user (id)
    ON DELETE RESTRICT,

  CONSTRAINT item_created_on_timestamp_iso8601_format
    CHECK (datetime(created_on_timestamp) = created_on_timestamp)
) STRICT;
