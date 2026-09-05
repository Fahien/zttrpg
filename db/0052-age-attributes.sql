-- What an age does to each attribute when a character is created. A pair
-- with no row is not adjusted, which is every pair for an adult, so a zero
-- row would only be noise and is refused.
CREATE TABLE age_attributes (
    age INTEGER NOT NULL,
    attribute INTEGER NOT NULL,
    modifier INTEGER NOT NULL,
    FOREIGN KEY (age) REFERENCES ages(id) ON DELETE CASCADE,
    FOREIGN KEY (attribute) REFERENCES attributes(id) ON DELETE CASCADE,
    PRIMARY KEY (age, attribute),
    CHECK (modifier <> 0)
);
