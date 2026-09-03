CREATE TABLE character_skills (
    character INTEGER NOT NULL,
    skill INTEGER NOT NULL,
    value INTEGER NOT NULL,
    FOREIGN KEY (character) REFERENCES characters(id) ON DELETE CASCADE,
    FOREIGN KEY (skill) REFERENCES skills(id),
    PRIMARY KEY (character, skill),
    CHECK (value >= 0 AND value < 1024)
);
