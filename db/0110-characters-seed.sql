INSERT INTO character_creation_status (name) VALUES
    ('Attributes'),
    ('Specialization'),
    ('Skills'),
    ('Complete');

-- These rows skip the server, which is what fills a new character's pool of
-- trained skill points and picks a profession's sole specialization, so they
-- carry both. Alice's profession offers three, so hers stays open.
INSERT INTO characters (name, level, kin, profession, age, trained_skill_points, specialization) VALUES
    ('Alice', 1, 3, 1, 1, (SELECT trained_skill_count FROM ages WHERE id = 1), NULL),
    ('Bob', 2, 2, 2, 1, (SELECT trained_skill_count FROM ages WHERE id = 1),
        (SELECT id FROM profession_specializations WHERE profession = 2));
