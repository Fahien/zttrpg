CREATE TABLE professions (
    id SERIAL PRIMARY KEY,
    name TEXT UNIQUE NOT NULL,
    icon INTEGER NOT NULL,
    description TEXT NOT NULL,
    CHECK (name <> ''),
    CHECK (description <> ''),
    FOREIGN KEY (icon) REFERENCES icons(id)
);

CREATE TABLE profession_specializations (
    id SERIAL PRIMARY KEY,
    profession INTEGER NOT NULL,
    name TEXT NOT NULL,
    description TEXT NOT NULL,
    heroic_skill INTEGER,
    UNIQUE (profession, name),
    CHECK (name <> ''),
    CHECK (description <> ''),
    FOREIGN KEY (profession) REFERENCES professions(id) ON DELETE CASCADE,
    FOREIGN KEY (heroic_skill) REFERENCES skills(id)
);

CREATE TABLE profession_specialization_skills (
    specialization INTEGER NOT NULL,
    skill INTEGER NOT NULL,
    position INTEGER NOT NULL,
    PRIMARY KEY (specialization, skill),
    UNIQUE (specialization, position),
    CHECK (position >= 1 AND position <= 8),
    FOREIGN KEY (specialization) REFERENCES profession_specializations(id) ON DELETE CASCADE,
    FOREIGN KEY (skill) REFERENCES skills(id)
);

CREATE TABLE profession_specialization_items (
    specialization INTEGER NOT NULL,
    package_index INTEGER NOT NULL,
    position INTEGER NOT NULL,
    item INTEGER NOT NULL,
    PRIMARY KEY (specialization, package_index, position),
    CHECK (package_index >= 1),
    CHECK (position >= 1),
    FOREIGN KEY (specialization) REFERENCES profession_specializations(id) ON DELETE CASCADE,
    FOREIGN KEY (item) REFERENCES items(id)
);
