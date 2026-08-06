CREATE TABLE kins (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name TEXT NOT NULL,
    CHECK (name <> '')
);

INSERT INTO kins (name) VALUES
    ('Human'),
    ('Orc'),
    ('Undead');