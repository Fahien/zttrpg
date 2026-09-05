-- Every character has one row per attribute, starting at the configured
-- default with nothing spent and nothing adjusted. STRICT turns a missing
-- 'attribute_default' row into an error that names it, rather than a NULL that
-- fails further down as a NOT NULL violation.
CREATE FUNCTION seed_character_attributes() RETURNS TRIGGER AS $fn$
DECLARE
    default_value INTEGER;
BEGIN
    SELECT value::INTEGER INTO STRICT default_value
    FROM configs
    WHERE name = 'attribute_default';

    INSERT INTO character_attributes (character, attribute, base)
    SELECT NEW.id, a.id, default_value
    FROM attributes a;
    RETURN NULL;
END;
$fn$ LANGUAGE plpgsql;

CREATE TRIGGER characters_seed_attributes
AFTER INSERT ON characters
FOR EACH ROW
EXECUTE FUNCTION seed_character_attributes();
