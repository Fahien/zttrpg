CREATE TABLE ages (
    id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name TEXT UNIQUE NOT NULL,
    icon INTEGER NOT NULL,
    trained_skill_count INTEGER NOT NULL,
    CHECK (name <> ''),
    CHECK (trained_skill_count IN (8, 10, 12)),
    FOREIGN KEY (icon) REFERENCES icons(id)
);
