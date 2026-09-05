INSERT INTO age_attributes (age, attribute, modifier) VALUES
    ((SELECT id FROM ages WHERE name = $val$Young$val$ LIMIT 1), (SELECT id FROM attributes WHERE name = $val$Agility$val$ LIMIT 1), $val$1$val$),
    ((SELECT id FROM ages WHERE name = $val$Young$val$ LIMIT 1), (SELECT id FROM attributes WHERE name = $val$Constitution$val$ LIMIT 1), $val$1$val$),
    ((SELECT id FROM ages WHERE name = $val$Old$val$ LIMIT 1), (SELECT id FROM attributes WHERE name = $val$Strength$val$ LIMIT 1), $val$-2$val$),
    ((SELECT id FROM ages WHERE name = $val$Old$val$ LIMIT 1), (SELECT id FROM attributes WHERE name = $val$Agility$val$ LIMIT 1), $val$-2$val$),
    ((SELECT id FROM ages WHERE name = $val$Old$val$ LIMIT 1), (SELECT id FROM attributes WHERE name = $val$Constitution$val$ LIMIT 1), $val$-2$val$),
    ((SELECT id FROM ages WHERE name = $val$Old$val$ LIMIT 1), (SELECT id FROM attributes WHERE name = $val$Intelligence$val$ LIMIT 1), $val$1$val$),
    ((SELECT id FROM ages WHERE name = $val$Old$val$ LIMIT 1), (SELECT id FROM attributes WHERE name = $val$Willpower$val$ LIMIT 1), $val$1$val$);
