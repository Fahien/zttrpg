CREATE TABLE skills (
    id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name TEXT UNIQUE NOT NULL,
    icon INTEGER NOT NULL,
    type TEXT NOT NULL,
    description TEXT NOT NULL,
    CHECK (name <> ''),
    CHECK(type <> ''),
    CHECK (description <> ''),
    FOREIGN KEY (icon) REFERENCES icons(id)
);
