-- Every character has one row per attribute.
CREATE FUNCTION seed_character_attributes() RETURNS TRIGGER AS $fn$
BEGIN
    INSERT INTO character_attributes (character, attribute, value)
    SELECT NEW.id, a.id, 0
    FROM attributes a;
    RETURN NULL;
END;
$fn$ LANGUAGE plpgsql;

CREATE TRIGGER characters_seed_attributes
AFTER INSERT ON characters
FOR EACH ROW
EXECUTE FUNCTION seed_character_attributes();
