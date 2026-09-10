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

-- The configured chance for a base-chance skill at the character's current
-- governing attribute. Skills without a base chance, and abilities without a
-- governing attribute, return NULL.
CREATE FUNCTION starting_skill_value(selected_character INTEGER, selected_skill INTEGER) RETURNS INTEGER AS $fn$
DECLARE
    level INTEGER;
BEGIN
    SELECT chance.base_chance
    INTO level
    FROM skills s
    JOIN skill_kinds kind ON kind.id = s.kind AND kind.base_chance
    JOIN character_attributes ca
      ON ca.character = selected_character AND ca.attribute = s.attribute
    JOIN skill_base_chances chance
      ON ca.value BETWEEN chance.min_value AND chance.max_value
    WHERE s.id = selected_skill;
    RETURN level;
END;
$fn$ LANGUAGE plpgsql STABLE;

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

-- Age and profession changes invalidate all partially chosen starting levels.
-- The reset is one transaction with the item update: the new age's pool and
-- attribute modifiers are visible together, and no old selection survives.
CREATE FUNCTION reset_character_creation() RETURNS TRIGGER AS $fn$
BEGIN
    IF NEW.age IS DISTINCT FROM OLD.age THEN
        UPDATE character_attributes ca
        SET modifier = COALESCE((
            SELECT aa.modifier
            FROM age_attributes aa
            WHERE aa.age = NEW.age AND aa.attribute = ca.attribute
        ), 0)
        WHERE ca.character = NEW.id;
    END IF;

    IF NEW.profession IS DISTINCT FROM OLD.profession OR NEW.age IS DISTINCT FROM OLD.age THEN
        UPDATE character_skills cs
        SET trained = FALSE,
            value = CASE
                WHEN kind.base_chance AND s.attribute IS NOT NULL AND NEW.attribute_points = 0
                    THEN starting_skill_value(NEW.id, cs.skill)
                ELSE 0
            END
        FROM skills s
        JOIN skill_kinds kind ON kind.id = s.kind
        WHERE cs.character = NEW.id
          AND cs.skill = s.id
          AND (cs.trained OR cs.value <> CASE
                WHEN kind.base_chance AND s.attribute IS NOT NULL AND NEW.attribute_points = 0
                    THEN starting_skill_value(NEW.id, cs.skill)
                ELSE 0
              END);

        -- A binary skill attached to the retained specialization is a grant,
        -- rather than a chance derived from an attribute or a spent point.
        UPDATE character_skills cs
        SET value = 1,
            trained = TRUE
        FROM profession_specialization_skills pss
        JOIN skills s ON s.id = pss.skill
        JOIN skill_kinds kind ON kind.id = s.kind
        WHERE cs.character = NEW.id
          AND cs.skill = pss.skill
          AND pss.specialization = NEW.specialization
          AND s.attribute IS NOT NULL
          AND NOT kind.base_chance;

        UPDATE characters c
        SET trained_skill_points = a.trained_skill_count
        FROM ages a
        WHERE c.id = NEW.id AND a.id = NEW.age;
    END IF;
    RETURN NULL;
END;
$fn$ LANGUAGE plpgsql;

CREATE TRIGGER characters_reset_creation
AFTER UPDATE OF profession, age ON characters
FOR EACH ROW
WHEN (OLD.profession IS DISTINCT FROM NEW.profession OR OLD.age IS DISTINCT FROM NEW.age)
EXECUTE FUNCTION reset_character_creation();
