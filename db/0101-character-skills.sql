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

-- The two point balances are the authoritative creation state. The creation
-- action keeps the specialization quota valid before it can empty its pool;
-- after creation, later skill advancement must not make status depend on
-- whether a skill's current value still looks like a starting selection.
CREATE FUNCTION character_creation_complete(character_id INTEGER) RETURNS BOOLEAN AS $fn$
BEGIN
    RETURN EXISTS (
        SELECT 1
        FROM characters c
        WHERE c.id = character_id
          AND c.attribute_points = 0
          AND c.trained_skill_points = 0
          AND c.specialization IS NOT NULL
    );
END;
$fn$ LANGUAGE plpgsql STABLE;

-- A profession with one specialization has no meaningful choice to ask of a
-- player. Store it on insert, and select it again if a profession edit narrows
-- the choice to one.
CREATE FUNCTION select_sole_specialization() RETURNS TRIGGER AS $fn$
BEGIN
    SELECT CASE WHEN COUNT(*) = 1 THEN MIN(id) ELSE NULL END
    INTO NEW.specialization
    FROM profession_specializations
    WHERE profession = NEW.profession;
    RETURN NEW;
END;
$fn$ LANGUAGE plpgsql;

CREATE TRIGGER characters_select_sole_specialization_on_insert
BEFORE INSERT ON characters
FOR EACH ROW
EXECUTE FUNCTION select_sole_specialization();

-- Generic character PUT bodies always include `profession`. Only a changed
-- profession should replace an existing multi-profession choice; an unchanged
-- one must preserve the selection and its already-spent training points.
CREATE TRIGGER characters_select_sole_specialization_on_profession_change
BEFORE UPDATE OF profession ON characters
FOR EACH ROW
WHEN (OLD.profession IS DISTINCT FROM NEW.profession)
EXECUTE FUNCTION select_sole_specialization();

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

CREATE FUNCTION refresh_character_trained_skills(character_id INTEGER) RETURNS VOID AS $fn$
BEGIN
    -- Before the first allocation is complete, zero distinguishes stored state
    -- from the draft values shown by the browser. Afterwards every base-chance
    -- skill has its configured starting value, doubled exactly once if trained.
    IF NOT EXISTS (
        SELECT 1 FROM characters
        WHERE id = character_id AND attribute_points = 0
    ) THEN
        RETURN;
    END IF;

    UPDATE character_skills cs
    SET value = starting_skill_value(character_id, cs.skill) *
        CASE WHEN cs.trained THEN 2 ELSE 1 END
    FROM skills s
    JOIN skill_kinds kind ON kind.id = s.kind
    WHERE cs.character = character_id
      AND cs.skill = s.id
      AND kind.base_chance;
END;
$fn$ LANGUAGE plpgsql;

CREATE FUNCTION refresh_trained_skills_after_attribute_change() RETURNS TRIGGER AS $fn$
BEGIN
    PERFORM refresh_character_trained_skills(NEW.character);
    RETURN NULL;
END;
$fn$ LANGUAGE plpgsql;

CREATE TRIGGER character_attributes_refresh_trained_skills
AFTER UPDATE OF base, spent, modifier ON character_attributes
FOR EACH ROW
WHEN (OLD.base IS DISTINCT FROM NEW.base OR OLD.spent IS DISTINCT FROM NEW.spent OR OLD.modifier IS DISTINCT FROM NEW.modifier)
EXECUTE FUNCTION refresh_trained_skills_after_attribute_change();

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

-- The profession quota is campaign configuration. It is a minimum within the
-- age's total training budget, so any remaining choices may also come from the
-- selected profession.
CREATE FUNCTION configured_profession_skill_minimum() RETURNS INTEGER AS $fn$
DECLARE
    configured INTEGER;
BEGIN
    SELECT value::INTEGER
    INTO STRICT configured
    FROM configs
    WHERE name = 'profession_skill_minimum';
    IF configured < 0 THEN
        RAISE EXCEPTION 'invalid config: profession_skill_minimum';
    END IF;
    RETURN configured;
EXCEPTION
    WHEN NO_DATA_FOUND THEN
        RAISE EXCEPTION 'missing config: profession_skill_minimum';
END;
$fn$ LANGUAGE plpgsql STABLE;

-- Adds one or more selections to an unfinished character. The array is a
-- delta, not a replacement: retrying an already-trained skill is a no-op and
-- never charges twice. A saved choice cannot be refunded, like spent
-- attribute points, so specialization also locks once this pool changes.
CREATE FUNCTION save_character_creation(
    selected_character INTEGER,
    selected_specialization INTEGER,
    selected_skills INTEGER[]
) RETURNS VOID AS $fn$
DECLARE
    remaining_points INTEGER;
    remaining_attribute_points INTEGER;
    selected_specialization_id INTEGER;
    existing_specialization_count INTEGER;
    new_skill_count INTEGER;
    new_specialization_count INTEGER;
    minimum_profession_skills INTEGER;
BEGIN
    -- Lock the character while checking both creation pools. An attribute
    -- save cannot race a training save past this persisted-state rule.
    SELECT trained_skill_points, attribute_points, specialization
    INTO STRICT remaining_points, remaining_attribute_points, selected_specialization_id
    FROM characters
    WHERE id = selected_character
    FOR UPDATE;

    IF selected_specialization IS NULL OR NOT EXISTS (
        SELECT 1
        FROM characters c
        JOIN profession_specializations ps ON ps.profession = c.profession
        WHERE c.id = selected_character AND ps.id = selected_specialization
    ) THEN
        RAISE EXCEPTION 'specialization does not belong to the character profession'
            USING ERRCODE = 'check_violation';
    END IF;

    IF selected_specialization_id IS NOT NULL AND selected_specialization_id <> selected_specialization AND EXISTS (
        SELECT 1
        FROM character_skills cs
        JOIN skills s ON s.id = cs.skill
        JOIN skill_kinds kind ON kind.id = s.kind
        WHERE cs.character = selected_character AND kind.base_chance AND cs.trained
    ) THEN
        RAISE EXCEPTION 'specialization cannot change after creation begins'
            USING ERRCODE = 'check_violation';
    END IF;

    IF selected_skills IS NULL OR cardinality(selected_skills) <> (
        SELECT COUNT(DISTINCT selected.skill)
        FROM unnest(selected_skills) AS selected(skill)
    ) THEN
        RAISE EXCEPTION 'trained skill request contains a duplicate'
            USING ERRCODE = 'check_violation';
    END IF;

    -- A specialization may still be chosen before attributes are finished,
    -- but selecting any base-chance skill must wait until every attribute point
    -- is saved. Its binary specialization skill is granted below and costs no
    -- point.
    IF cardinality(selected_skills) > 0 AND remaining_attribute_points > 0 THEN
        RAISE EXCEPTION 'all attribute points must be spent before training skills'
            USING ERRCODE = 'check_violation';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM unnest(selected_skills) AS selected(skill)
        LEFT JOIN skills s ON s.id = selected.skill
        LEFT JOIN skill_kinds kind ON kind.id = s.kind
        WHERE s.attribute IS NULL OR NOT kind.base_chance
    ) THEN
        RAISE EXCEPTION 'selected skills must use a governing attribute and base chance'
            USING ERRCODE = 'check_violation';
    END IF;

    -- A complete character may retry its final request, but cannot add a new
    -- skill through creation after the pool is exhausted.
    IF character_creation_complete(selected_character) THEN
        IF selected_specialization_id <> selected_specialization OR EXISTS (
            SELECT 1
            FROM unnest(selected_skills) AS selected(skill)
            JOIN character_skills cs ON cs.character = selected_character AND cs.skill = selected.skill
            WHERE NOT cs.trained
        ) THEN
            RAISE EXCEPTION 'a completed character cannot spend trained skill points'
                USING ERRCODE = 'check_violation';
        END IF;
        RETURN;
    END IF;

    SELECT COUNT(*)
    INTO existing_specialization_count
    FROM character_skills cs
    JOIN profession_specialization_skills pss
      ON pss.specialization = selected_specialization AND pss.skill = cs.skill
    JOIN skills s ON s.id = cs.skill
    JOIN skill_kinds kind ON kind.id = s.kind
    WHERE cs.character = selected_character AND cs.trained AND kind.base_chance;

    SELECT COUNT(*)
    INTO new_skill_count
    FROM unnest(selected_skills) AS selected(skill)
    JOIN character_skills cs ON cs.character = selected_character AND cs.skill = selected.skill
    WHERE NOT cs.trained;

    SELECT COUNT(*)
    INTO new_specialization_count
    FROM unnest(selected_skills) AS selected(skill)
    JOIN character_skills cs ON cs.character = selected_character AND cs.skill = selected.skill
    JOIN profession_specialization_skills pss
      ON pss.specialization = selected_specialization AND pss.skill = selected.skill
    JOIN skills s ON s.id = cs.skill
    JOIN skill_kinds kind ON kind.id = s.kind
    WHERE NOT cs.trained AND kind.base_chance;

    IF new_skill_count > remaining_points THEN
        RAISE EXCEPTION 'not enough trained skill points'
            USING ERRCODE = 'check_violation';
    END IF;

    minimum_profession_skills := configured_profession_skill_minimum();

    IF remaining_points - new_skill_count = 0 AND
       existing_specialization_count + new_specialization_count < minimum_profession_skills THEN
        RAISE EXCEPTION 'the final trained skill point requires the minimum profession skills'
            USING ERRCODE = 'check_violation';
    END IF;

    -- Outside-profession choices are free while enough unspent slots remain
    -- to reach the configured minimum. Profession choices have no upper bound
    -- other than the character's total training budget.
    IF existing_specialization_count + new_specialization_count +
       (remaining_points - new_skill_count) < minimum_profession_skills THEN
        RAISE EXCEPTION 'creation must reserve the minimum profession skills'
            USING ERRCODE = 'check_violation';
    END IF;

    -- Replacing a specialization before a base-chance skill is chosen also
    -- replaces its binary grant. The relationship supplies the matching skill,
    -- so this does not depend on profession, specialization, or kind names.
    UPDATE character_skills cs
    SET value = 0,
        trained = FALSE
    FROM profession_specialization_skills old_pss
    JOIN skills s ON s.id = old_pss.skill
    JOIN skill_kinds kind ON kind.id = s.kind
    WHERE cs.character = selected_character
      AND cs.skill = old_pss.skill
      AND old_pss.specialization = selected_specialization_id
      AND s.attribute IS NOT NULL
      AND NOT kind.base_chance
      AND NOT EXISTS (
          SELECT 1
          FROM profession_specialization_skills new_pss
          WHERE new_pss.specialization = selected_specialization
            AND new_pss.skill = cs.skill
      );

    UPDATE characters
    SET specialization = selected_specialization,
        trained_skill_points = trained_skill_points - new_skill_count
    WHERE id = selected_character;

    -- Binary skills linked to the selected specialization are learned at level
    -- one. They neither use a base chance nor consume trained-skill points.
    UPDATE character_skills cs
    SET value = 1,
        trained = TRUE
    FROM profession_specialization_skills pss
    JOIN skills s ON s.id = pss.skill
    JOIN skill_kinds kind ON kind.id = s.kind
    WHERE cs.character = selected_character
      AND cs.skill = pss.skill
      AND pss.specialization = selected_specialization
      AND s.attribute IS NOT NULL
      AND NOT kind.base_chance;

    UPDATE character_skills cs
    SET value = cs.value * 2,
        trained = TRUE
    FROM unnest(selected_skills) AS selected(skill)
    WHERE cs.character = selected_character
      AND cs.skill = selected.skill
      AND NOT cs.trained;
END;
$fn$ LANGUAGE plpgsql;
