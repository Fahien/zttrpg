CREATE TABLE item_kinds (
    id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name TEXT UNIQUE NOT NULL,
    icon INTEGER NOT NULL,
    CHECK (name <> ''),
    FOREIGN KEY (icon) REFERENCES icons(id)
);

CREATE TABLE item_supplies (
    id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name TEXT UNIQUE NOT NULL,
    color TEXT NOT NULL,
    CHECK (name <> ''),
    CHECK (color <> '')
);

CREATE TABLE items (
    id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name TEXT UNIQUE NOT NULL,
    icon INTEGER NOT NULL,
    kind INTEGER NOT NULL,
    cost INTEGER NOT NULL,
    supply INTEGER NOT NULL,
    weight FLOAT NOT NULL,
    effect TEXT,
    description TEXT NOT NULL,
    CHECK (name <> ''),
    CHECK (cost >= 0),
    CHECK (weight >= 0.0),
    CHECK (description <> ''),
    FOREIGN KEY (icon) REFERENCES icons(id),
    FOREIGN KEY (kind) REFERENCES item_kinds(id),
    FOREIGN KEY (supply) REFERENCES item_supplies(id)
);
