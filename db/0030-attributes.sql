CREATE TABLE attributes (
    id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name TEXT UNIQUE NOT NULL,
    icon INTEGER NOT NULL,
    short TEXT NOT NULL,
    description TEXT NOT NULL,
    CHECK (name <> ''),
    CHECK (short <> ''),
    CHECK (description <> ''),
    FOREIGN KEY (icon) REFERENCES icons(id)
);
