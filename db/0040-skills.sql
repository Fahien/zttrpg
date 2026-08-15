CREATE TABLE skill_kinds (
    id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name TEXT UNIQUE NOT NULL,
    CHECK (name <> '')
);

CREATE TABLE skills (
    id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name TEXT UNIQUE NOT NULL,
    icon INTEGER NOT NULL,
    kind INTEGER NOT NULL,
    description TEXT NOT NULL,
    CHECK (name <> ''),
    CHECK (description <> ''),
    FOREIGN KEY (icon) REFERENCES icons(id),
    FOREIGN KEY (kind) REFERENCES skill_kinds(id)
);
