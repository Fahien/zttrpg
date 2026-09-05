-- A value on a sheet is three facts added together, kept apart so each can
-- follow its own rule: where the attribute started, what the player spent on
-- it, and what the rules adjusted. `value` is generated from them, so the
-- formula exists once and lives here.
CREATE TABLE character_attributes (
    character INTEGER NOT NULL,
    attribute INTEGER NOT NULL,
    -- The configured default at creation.
    base INTEGER NOT NULL,
    -- Points the player put here. Only ever grows, and every point leaves the
    -- character's pool: see 0072 and 0073.
    spent INTEGER NOT NULL DEFAULT 0,
    -- The rules' adjustments: age at creation, a game master's call during
    -- play. Either sign, and never touches the pool.
    modifier INTEGER NOT NULL DEFAULT 0,
    value INTEGER GENERATED ALWAYS AS (base + spent + modifier) STORED,
    FOREIGN KEY (character) REFERENCES characters(id) ON DELETE CASCADE,
    FOREIGN KEY (attribute) REFERENCES attributes(id),
    PRIMARY KEY (character, attribute),
    CHECK (spent >= 0)
);
