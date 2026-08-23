CREATE TABLE character_attributes (
    character INTEGER NOT NULL,
    attribute INTEGER NOT NULL,
    value INTEGER NOT NULL,
    FOREIGN KEY (character) REFERENCES characters(id) ON DELETE CASCADE,
    FOREIGN KEY (attribute) REFERENCES attributes(id),
    PRIMARY KEY (character, attribute),
    CHECK (value >= 0 AND value < 1024)
);
