INSERT INTO damage_bonuses (attribute, min_value, die_sides) VALUES
    ((SELECT id FROM attributes WHERE name = $val$Strength$val$ LIMIT 1), $val$13$val$, $val$4$val$),
    ((SELECT id FROM attributes WHERE name = $val$Strength$val$ LIMIT 1), $val$17$val$, $val$6$val$),
    ((SELECT id FROM attributes WHERE name = $val$Agility$val$ LIMIT 1), $val$13$val$, $val$4$val$),
    ((SELECT id FROM attributes WHERE name = $val$Agility$val$ LIMIT 1), $val$17$val$, $val$6$val$);
