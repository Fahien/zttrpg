CREATE TABLE characters (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name TEXT NOT NULL,
    level INTEGER NOT NULL,
    CHECK (level >= 1 AND level <= 100),
    CHECK (name <> '')
);

INSERT INTO characters (name, level) VALUES
    ('Alice', 1),
    ('Bob', 2),
    ('Charlie', 3);