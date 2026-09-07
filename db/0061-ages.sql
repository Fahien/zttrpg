INSERT INTO ages (name, icon) VALUES
    ($val$Young$val$, (SELECT id FROM icons WHERE name = $val$baby-face$val$ LIMIT 1)),
    ($val$Adult$val$, (SELECT id FROM icons WHERE name = $val$person$val$ LIMIT 1)),
    ($val$Old$val$, (SELECT id FROM icons WHERE name = $val$wizard-face$val$ LIMIT 1));
