CREATE TABLE skills (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name TEXT NOT NULL,
    icon INTEGER NOT NULL,
    CHECK (name <> ''),
    FOREIGN KEY (icon) REFERENCES icons(id)
);

INSERT INTO skills (name, icon) VALUES
    ('Fireball', 1),
    ('Heal', 1),
    ('Stealth', 1);
