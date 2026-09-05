-- What a band of one attribute's values adds to a character's movement. Rows
-- rather than code: which attribute drives movement, and by how much, is game
-- data. Movement itself is never stored. The server derives it on every read
-- from the kin's base and these bands, so an edited attribute is right at once.
CREATE TABLE movement_modifiers (
    id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    attribute INTEGER NOT NULL,
    min_value INTEGER NOT NULL,
    max_value INTEGER NOT NULL,
    modifier INTEGER NOT NULL,
    FOREIGN KEY (attribute) REFERENCES attributes(id) ON DELETE CASCADE,
    CHECK (min_value <= max_value)
);
