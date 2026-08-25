-- Every character has one row per skill.
INSERT INTO character_skills (character, skill, value)
SELECT c.id, s.id, 0
FROM characters c
CROSS JOIN skills s
ON CONFLICT (character, skill) DO NOTHING;

CREATE FUNCTION seed_character_skills() RETURNS TRIGGER AS $fn$
BEGIN
    INSERT INTO character_skills (character, skill, value)
    SELECT NEW.id, s.id, 0
    FROM skills s;
    RETURN NULL;
END;
$fn$ LANGUAGE plpgsql;

CREATE TRIGGER characters_seed_skills
AFTER INSERT ON characters
FOR EACH ROW
EXECUTE FUNCTION seed_character_skills();
