-- Every character has one row per skill, starting at zero until its attribute
-- allocation is committed. Training is explicit because an untrained governed
-- skill also has a positive value after that point.
CREATE FUNCTION seed_character_skills() RETURNS TRIGGER AS $fn$
BEGIN
    INSERT INTO character_skills (character, skill, value, trained)
    SELECT NEW.id, s.id, 0, FALSE
    FROM skills s;
    RETURN NULL;
END;
$fn$ LANGUAGE plpgsql;

CREATE TRIGGER characters_seed_skills
AFTER INSERT ON characters
FOR EACH ROW
EXECUTE FUNCTION seed_character_skills();

-- A non-base-chance skill with a governing attribute is a binary learned
-- capability. Abilities keep their existing representation: they have no
-- governing attribute and do not enter this rule.
CREATE FUNCTION check_binary_secondary_skill() RETURNS TRIGGER AS $fn$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM skills s
        JOIN skill_kinds kind ON kind.id = s.kind
        WHERE s.id = NEW.skill
          AND s.attribute IS NOT NULL
          AND NOT kind.base_chance
    ) AND ((NEW.value = 0 AND NEW.trained) OR
           (NEW.value = 1 AND NOT NEW.trained) OR
           NEW.value NOT IN (0, 1)) THEN
        RAISE EXCEPTION 'a binary skill must be 0 when unlearned or 1 when learned'
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$fn$ LANGUAGE plpgsql;

CREATE TRIGGER character_skills_check_binary_secondary
BEFORE INSERT OR UPDATE OF value, trained ON character_skills
FOR EACH ROW
EXECUTE FUNCTION check_binary_secondary_skill();
