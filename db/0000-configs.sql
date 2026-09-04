CREATE TABLE configs (
   id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
   name TEXT UNIQUE NOT NULL,
   value TEXT NOT NULL,
   CHECK (name <> ''),
   CHECK (value <> '')
);
