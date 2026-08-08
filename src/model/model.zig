const character = @import("character.zig");

pub const BodyCharacter = character.BodyCharacter;
pub const CreateCharacter = character.CreateCharacter;
pub const UpdateCharacter = character.UpdateCharacter;
pub const Character = character.Character;

const kin = @import("kin.zig");
pub const Kin = kin.Kin;

test {
    // Test discovery is lazy: a file's tests are only collected when the file
    // is referenced from a test context, so name each model file here.
    _ = character;
    _ = kin;
}
