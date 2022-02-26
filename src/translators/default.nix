{
  coreutils,
  dlib,
  jq,
  lib,
  nix,
  pkgs,

  callPackageDream,
  externals,
  dream2nixWithExternals,
  utils,
  ...
}:

let

  b = builtins;

  l = lib // builtins;

  # transforms all V1 translators to V2 translators
  ensureTranslatorV2 = translator:
    let
      version = translator.version or 1;
      cleanedArgs = args: l.removeAttrs args [ "projets" "tree" ];

      upgradedTranslator =
        translator // {
          translate = args:
            l.map
              (proj: proj // {
                dreamLock = translator.translate
                  ((cleanedArgs args) // {
                    source = "${args.source}${proj.relPath}";
                  });
              })
              args.projects;
        };
    in
      if version == 2 then
        translator
      else
        upgradedTranslator;


  makeTranslatorV2 = translatorModule:
    ensureTranslatorV2 (makeTranslator translatorModule);


  makeTranslator =
    translatorModule:
      let
        translator =
          translatorModule

          # for pure translators
          #   - import the `translate` function
          #   - generate `translateBin`
          // (lib.optionalAttrs (translatorModule ? translate) {
            translate = callPackageDream translatorModule.translate {
              translatorName = translatorModule.name;
            };
            translateBin =
              wrapPureTranslator
              (with translatorModule; [ subsystem type name ]);
          })

          # for impure translators:
          #   - import the `translateBin` function
          // (lib.optionalAttrs (translatorModule ? translateBin) {
            translateBin = callPackageDream translatorModule.translateBin
              {
                translatorName = translatorModule.name;
              };
          });

          # supply calls to translate with default arguments
          translatorWithDefaults = translator // {
            translate = args:
              translator.translate
                (
                  (dlib.translators.getextraArgsDefaults
                    (translator.extraArgs or {}))
                  // args
                );
          };

      in
        translatorWithDefaults;


  translators = dlib.translators.mapTranslators makeTranslator;

  translatorsV2 = dlib.translators.mapTranslators makeTranslatorV2;


  # adds a translateBin to a pure translator
  wrapPureTranslator = translatorAttrPath:
    let
      bin = utils.writePureShellScript
        [
          coreutils
          jq
          nix
        ]
        ''
          jsonInputFile=$(realpath $1)
          outputFile=$(jq '.outputFile' -c -r $jsonInputFile)

          nix eval --show-trace --impure --raw --expr "
              let
                dream2nix = import ${dream2nixWithExternals} {};
                dreamLock =
                  dream2nix.translators.translators.${
                    lib.concatStringsSep "." translatorAttrPath
                  }.translate
                    (builtins.fromJSON (builtins.readFile '''$1'''));
              in
                dream2nix.utils.dreamLock.toJSON
                  # don't use nix to detect cycles, this will be more efficient in python
                  (dreamLock // {
                    _generic = builtins.removeAttrs dreamLock._generic [ \"cyclicDependencies\" ];
                  })
          " | jq > $outputFile
        '';
    in
      bin.overrideAttrs (old: {
        name = "translator-${lib.concatStringsSep "-" translatorAttrPath}";
      });



in
{
  inherit
    translators
    translatorsV2
  ;

  inherit (dlib.translators)
    findOneTranslator
    translatorsForInput
    translatorsForInputRecursive
  ;
}
