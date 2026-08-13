INSERT INTO attributes (name, icon, short, description) VALUES
    ('Strength', (SELECT id FROM icons WHERE name = 'fist' LIMIT 1), 'STR', 'Raw muscle power.'),
    ('Constitution', (SELECT id FROM icons WHERE name = 'muscle-up' LIMIT 1), 'CON', 'Physical fitness and resilience.'),
    ('Agility', (SELECT id FROM icons WHERE name = 'wingfoot' LIMIT 1), 'AGL', 'Body control, speed, and fine motor skills.'),
    ('Intelligence', (SELECT id FROM icons WHERE name = 'brain' LIMIT 1), 'INT', 'Mental acuity, intellect, and reasoning skills.'),
    ('Willpower', (SELECT id FROM icons WHERE name = 'suspicious' LIMIT 1), 'WIL', 'Self-discipline and focus.'),
    ('Charisma', (SELECT id FROM icons WHERE name = 'polar-star' LIMIT 1), 'CHA', 'Force of personality and empathy.');
