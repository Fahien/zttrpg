CREATE TABLE characters (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name TEXT NOT NULL,
    level INTEGER NOT NULL,
    kin INTEGER NOT NULL,
    CHECK (level >= 1 AND level <= 100),
    CHECK (name <> ''),
    FOREIGN KEY (kin) REFERENCES kins(id)
);

INSERT INTO characters (name, level, kin) VALUES
    ('Alice', 1, 3),
    ('Bob', 2, 2),
    ('Charlie', 3, 1);
