CREATE TABLE characters (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name TEXT NOT NULL,
    level INTEGER NOT NULL
);

INSERT INTO characters (name, level) VALUES
    ('Alice', 1),
    ('Bob', 2),
    ('Charlie', 3);