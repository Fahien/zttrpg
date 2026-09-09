-- Every character has one row per skill, starting at zero until its attribute
-- allocation is committed. Training is explicit because an untrained governed
-- skill also has a positive value after that point.
INSERT INTO character_skills (character, skill, value, trained)
SELECT c.id, s.id, 0, FALSE
FROM characters c
CROSS JOIN skills s
ON CONFLICT (character, skill) DO NOTHING;

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

-- Age owns the size of this pool, just as it owns the visible trained-skill
-- count. This is a row-local insert trigger because a DEFAULT cannot inspect
-- NEW.age.
CREATE FUNCTION seed_trained_skill_points() RETURNS TRIGGER AS $fn$
BEGIN
    SELECT trained_skill_count
    INTO STRICT NEW.trained_skill_points
    FROM ages
    WHERE id = NEW.age;
    RETURN NEW;
END;
$fn$ LANGUAGE plpgsql;

CREATE TRIGGER characters_seed_trained_skill_points
BEFORE INSERT ON characters
FOR EACH ROW
EXECUTE FUNCTION seed_trained_skill_points();

-- The configured chance for a skill at the character's current governing
-- attribute. An ability has no governing attribute and therefore returns NULL.
CREATE FUNCTION starting_skill_value(selected_character INTEGER, selected_skill INTEGER) RETURNS INTEGER AS $fn$
DECLARE
    level INTEGER;
BEGIN
    SELECT chance.base_chance
    INTO level
    FROM skills s
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
    -- from the draft values shown by the browser. Afterwards every governed
    -- skill has its configured starting value, doubled exactly once if trained.
    IF NOT EXISTS (
        SELECT 1 FROM characters
        WHERE id = character_id AND attribute_points = 0
    ) THEN
        RETURN;
    END IF;

    PERFORM set_config('zttrpg.creation_write', 'on', true);
    UPDATE character_skills cs
    SET value = starting_skill_value(character_id, cs.skill) *
        CASE WHEN cs.trained THEN 2 ELSE 1 END
    FROM skills s
    WHERE cs.character = character_id
      AND cs.skill = s.id
      AND s.attribute IS NOT NULL;
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

-- The generic /skills endpoint is normal advancement only after both pools
-- are empty. Before then, save_character_creation is the sole path allowed to
-- mark a skill trained, so it can debit exactly one trained-skill point.
CREATE FUNCTION reject_direct_creation_skill_write() RETURNS TRIGGER AS $fn$
BEGIN
    IF NOT character_creation_complete(NEW.character)
       AND current_setting('zttrpg.creation_write', true) IS DISTINCT FROM 'on' THEN
        RAISE EXCEPTION 'an incomplete character must train skills through creation'
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$fn$ LANGUAGE plpgsql;

CREATE TRIGGER character_skills_reject_direct_creation_write
BEFORE UPDATE OF value ON character_skills
FOR EACH ROW
WHEN (NEW.value IS DISTINCT FROM OLD.value)
EXECUTE FUNCTION reject_direct_creation_skill_write();

-- Age and profession changes invalidate all partially chosen starting levels.
-- The reset is one transaction with the item update: the new age's pool and
-- attribute modifiers are visible together, and no old selection survives.
CREATE FUNCTION reset_character_creation() RETURNS TRIGGER AS $fn$
BEGIN
    PERFORM set_config('zttrpg.creation_write', 'on', true);

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
                WHEN s.attribute IS NULL THEN 0
                WHEN NEW.attribute_points = 0 THEN starting_skill_value(NEW.id, cs.skill)
                ELSE 0
            END
        FROM skills s
        WHERE cs.character = NEW.id
          AND cs.skill = s.id
          AND (cs.trained OR cs.value <> CASE
                WHEN s.attribute IS NULL THEN 0
                WHEN NEW.attribute_points = 0 THEN starting_skill_value(NEW.id, cs.skill)
                ELSE 0
              END);

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
        WHERE cs.character = selected_character AND s.attribute IS NOT NULL AND cs.trained
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
    -- but selecting any skill must wait until every attribute point is saved.
    IF cardinality(selected_skills) > 0 AND remaining_attribute_points > 0 THEN
        RAISE EXCEPTION 'all attribute points must be spent before training skills'
            USING ERRCODE = 'check_violation';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM unnest(selected_skills) AS selected(skill)
        LEFT JOIN skills s ON s.id = selected.skill
        WHERE s.attribute IS NULL
    ) THEN
        RAISE EXCEPTION 'trained skills must have a governing attribute'
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
    WHERE cs.character = selected_character AND cs.trained;

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
    WHERE NOT cs.trained;

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

    PERFORM set_config('zttrpg.creation_write', 'on', true);

    UPDATE characters
    SET specialization = selected_specialization,
        trained_skill_points = trained_skill_points - new_skill_count
    WHERE id = selected_character;

    UPDATE character_skills cs
    SET value = cs.value * 2,
        trained = TRUE
    FROM unnest(selected_skills) AS selected(skill)
    WHERE cs.character = selected_character
      AND cs.skill = selected.skill
      AND NOT cs.trained;
END;
$fn$ LANGUAGE plpgsql;
