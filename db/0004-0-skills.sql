CREATE TABLE skills (
    id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name TEXT NOT NULL,
    icon INTEGER NOT NULL,
    description TEXT NOT NULL,
    CHECK (name <> ''),
    FOREIGN KEY (icon) REFERENCES icons(id)
);
