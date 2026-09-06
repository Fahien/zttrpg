-- One extra damage die, selected by the highest threshold the attribute meets.
-- Below the first threshold there is no bonus. Character bonuses are derived.
CREATE TABLE damage_bonuses (
    attribute INTEGER NOT NULL REFERENCES attributes(id) ON DELETE CASCADE,
    min_value INTEGER NOT NULL CHECK (min_value >= 0),
    die_sides INTEGER NOT NULL CHECK (die_sides >= 2),
    PRIMARY KEY (attribute, min_value)
);
