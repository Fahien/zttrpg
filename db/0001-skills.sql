CREATE TABLE skills (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name TEXT NOT NULL,
    CHECK (name <> '')
);

INSERT INTO skills (name) VALUES
    ('Fireball'),
    ('Heal'),
    ('Stealth');
