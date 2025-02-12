{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };
  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        name = "llama.cpp";
        src = ./.;
        meta.mainProgram = "llama";
        inherit (pkgs.stdenv) isAarch32 isAarch64 isDarwin;
        buildInputs = with pkgs; [ openmpi ];
        osSpecific = with pkgs; buildInputs ++ (
          if isAarch64 && isDarwin then
            with pkgs.darwin.apple_sdk_11_0.frameworks; [
              Accelerate
              MetalKit
            ]
          else if isAarch32 && isDarwin then
            with pkgs.darwin.apple_sdk.frameworks; [
              Accelerate
              CoreGraphics
              CoreVideo
            ]
          else if isDarwin then
            with pkgs.darwin.apple_sdk.frameworks; [
              Accelerate
              CoreGraphics
              CoreVideo
            ]
          else
            with pkgs; [ openblas ]
        );
        pkgs = import nixpkgs { inherit system; config = { allowUnfree = true; }; };
        nativeBuildInputs = with pkgs; [ cmake ninja pkg-config ];
        cudatoolkit_joined = { cudaPackages ? pkgs.cudaPackages_12_2 }: with pkgs; symlinkJoin {
          # HACK(Green-Sky): nix currently has issues with cmake findcudatoolkit
          # see https://github.com/NixOS/nixpkgs/issues/224291
          # copied from jaxlib
          name = "cudatoolkit";
          paths = with cudaPackages; [
            cuda_cccl
            cuda_cccl.dev
            cuda_cudart
            cuda_cupti
            cuda_nvcc
            cuda_nvcc.dev
            cuda_nvprof
            cuda_nvrtc
            cuda_nvtx
            nccl
            libcublas
            libcufft
            libcurand
            libcusparse
            libcusolver
            libnvjitlink
          ];
        };
        llama-python =
          pkgs.python3.withPackages (ps: with ps; [ numpy sentencepiece ]);
        # TODO(Green-Sky): find a better way to opt-into the heavy ml python runtime
        llama-python-extra =
          pkgs.python3.withPackages (ps: with ps; [ numpy sentencepiece torchWithoutCuda transformers ]);
        postPatch = ''
          substituteInPlace ./ggml-metal.m \
            --replace '[bundle pathForResource:@"ggml-metal" ofType:@"metal"];' "@\"$out/bin/ggml-metal.metal\";"
          substituteInPlace ./*.py --replace '/usr/bin/env python' '${llama-python}/bin/python'
        '';
        postInstall = ''
          mv $out/bin/main $out/bin/llama
          mv $out/bin/server $out/bin/llama-server
          mkdir -p $out/include
          cp ${src}/llama.h $out/include/
        '';
        cmakeFlags = [ "-DLLAMA_NATIVE=OFF" "-DLLAMA_BUILD_SERVER=ON" "-DBUILD_SHARED_LIBS=ON" "-DCMAKE_SKIP_BUILD_RPATH=ON" ];
      in
      {
        packages.default = pkgs.stdenv.mkDerivation {
          inherit name src meta postPatch nativeBuildInputs postInstall;
          buildInputs = osSpecific;
          cmakeFlags = cmakeFlags
            ++ (if isAarch64 && isDarwin then [
            "-DCMAKE_C_FLAGS=-D__ARM_FEATURE_DOTPROD=1"
            "-DLLAMA_METAL=ON"
          ] else [
            "-DLLAMA_BLAS=ON"
            "-DLLAMA_BLAS_VENDOR=OpenBLAS"
          ]);
        };
        packages.opencl = pkgs.stdenv.mkDerivation {
          inherit name src meta postPatch nativeBuildInputs postInstall;
          buildInputs = with pkgs; buildInputs ++ [ clblast ];
          cmakeFlags = cmakeFlags ++ [
            "-DLLAMA_CLBLAST=ON"
          ];
        };
        packages.cuda = pkgs.stdenv.mkDerivation (self: {
          inherit name src meta postPatch nativeBuildInputs postInstall;
          buildInputs = with pkgs; buildInputs ++ [ self.passthru.cudaToolkit ];
          cmakeFlags = cmakeFlags ++ [
            "-DLLAMA_CUBLAS=ON"
          ];
          passthru = {
            cudaPackages = pkgs.cudaPackages_12_2;
            cudaToolkit = cudatoolkit_joined { inherit (self.passthru) cudaPackages; };
          };
        });
        packages.rocm = pkgs.stdenv.mkDerivation {
          inherit name src meta postPatch nativeBuildInputs postInstall;
          buildInputs = with pkgs.rocmPackages; buildInputs ++ [ clr hipblas rocblas ];
          cmakeFlags = cmakeFlags ++ [
            "-DLLAMA_HIPBLAS=1"
            "-DCMAKE_C_COMPILER=hipcc"
            "-DCMAKE_CXX_COMPILER=hipcc"
            # Build all targets supported by rocBLAS. When updating search for TARGET_LIST_ROCM
            # in github.com/ROCmSoftwarePlatform/rocBLAS/blob/develop/CMakeLists.txt
            # and select the line that matches the current nixpkgs version of rocBLAS.
            "-DAMDGPU_TARGETS=gfx803;gfx900;gfx906:xnack-;gfx908:xnack-;gfx90a:xnack+;gfx90a:xnack-;gfx940;gfx941;gfx942;gfx1010;gfx1012;gfx1030;gfx1100;gfx1101;gfx1102"
          ];
        };
        apps.llama-server = {
          type = "app";
          program = "${self.packages.${system}.default}/bin/llama-server";
        };
        apps.llama-embedding = {
          type = "app";
          program = "${self.packages.${system}.default}/bin/embedding";
        };
        apps.llama = {
          type = "app";
          program = "${self.packages.${system}.default}/bin/llama";
        };
        apps.quantize = {
          type = "app";
          program = "${self.packages.${system}.default}/bin/quantize";
        };
        apps.train-text-from-scratch = {
          type = "app";
          program = "${self.packages.${system}.default}/bin/train-text-from-scratch";
        };
        apps.default = self.apps.${system}.llama;
        devShells.default = pkgs.mkShell {
          buildInputs = [ llama-python ];
          packages = nativeBuildInputs ++ osSpecific;
        };
        devShells.extra = pkgs.mkShell {
          buildInputs = [ llama-python-extra ];
          packages = nativeBuildInputs ++ osSpecific;
        };
      });
  nixConfig = {
    allowUnfree = true;
  };
}
