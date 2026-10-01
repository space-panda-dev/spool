{ mkDerivation, aeson, async, base, bytestring, containers, crypton
, directory, filepath, lib, memory, process, stm, tasty
, tasty-hunit, tasty-quickcheck, text, time, unix
}:
mkDerivation {
  pname = "spool";
  version = "0.0.2";
  src = ./.;
  isLibrary = true;
  isExecutable = true;
  libraryHaskellDepends = [
    aeson async base bytestring containers crypton directory filepath
    memory process stm text time unix
  ];
  executableHaskellDepends = [ base ];
  testHaskellDepends = [
    aeson base bytestring containers directory filepath process tasty
    tasty-hunit tasty-quickcheck text unix
  ];
  description = "A standalone file-backed JSONL task spool";
  license = lib.meta.getLicenseFromSpdxId "AGPL-3.0-or-later";
  mainProgram = "spool";
}
