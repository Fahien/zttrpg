CREATE TABLE icons (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name TEXT NOT NULL,
    CHECK (name <> '')
);

INSERT INTO icons (name) VALUES
    ('abacus');
