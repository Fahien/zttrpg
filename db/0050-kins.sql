CREATE TABLE kins (
    id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name TEXT UNIQUE NOT NULL,
    icon INTEGER NOT NULL,
    -- How far a character of this kin moves before agility adds or takes.
    movement INTEGER NOT NULL,
    CHECK (name <> ''),
    CHECK (movement > 0),
    FOREIGN KEY (icon) REFERENCES icons(id)
);

CREATE TABLE kins_skills (
    kin INTEGER NOT NULL,
    skill INTEGER NOT NULL,
    PRIMARY KEY (kin, skill),
    FOREIGN KEY (kin) REFERENCES kins(id),
    FOREIGN KEY (skill) REFERENCES skills(id)
);
