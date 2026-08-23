INSERT INTO character_attributes (character, attribute, value)
SELECT c.id, a.id, 0
FROM characters c
CROSS JOIN attributes a;
