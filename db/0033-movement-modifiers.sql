INSERT INTO movement_modifiers (attribute, min_value, max_value, modifier) VALUES
    ((SELECT id FROM attributes WHERE name = $val$Agility$val$ LIMIT 1), $val$1$val$, $val$6$val$, $val$-4$val$),
    ((SELECT id FROM attributes WHERE name = $val$Agility$val$ LIMIT 1), $val$7$val$, $val$9$val$, $val$-2$val$),
    ((SELECT id FROM attributes WHERE name = $val$Agility$val$ LIMIT 1), $val$10$val$, $val$12$val$, $val$0$val$),
    ((SELECT id FROM attributes WHERE name = $val$Agility$val$ LIMIT 1), $val$13$val$, $val$15$val$, $val$2$val$),
    ((SELECT id FROM attributes WHERE name = $val$Agility$val$ LIMIT 1), $val$16$val$, $val$18$val$, $val$4$val$);
