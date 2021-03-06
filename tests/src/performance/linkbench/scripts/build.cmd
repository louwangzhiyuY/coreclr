@echo off

REM Usage: Build.cmd <LinkBench assets directory>
setlocal

set AssetDir=%1
set ExitCode=0
mkdir LinkBench 2> nul
pushd %LinkBenchRoot%

set __CORFLAGS="%VS140COMNTOOLS%\..\..\..\Microsoft SDKs\Windows\v10.0A\bin\NETFX 4.6.1 Tools\CorFlags.exe"
if not exist %__CORFLAGS% (
    echo corflags.exe not found
    exit /b -1
)

if defined __test_HelloWorld call :HelloWorld
if defined __test_WebAPI call :WebAPI
if defined __test_MusicStore call :MusicStore
if defined __test_MusicStore_R2R call :MusicStore_R2R 
if defined __test_CoreFx call :CoreFx
if defined __test_Roslyn call :Roslyn

popd
exit /b %ExitCode%

:HelloWorld
echo Build ** HelloWorld **
pushd %LinkBenchRoot%\HelloWorld
%__dotnet2% restore -r win10-x64
%__dotnet2% publish -c release -r win10-x64 /p:LinkDuringPublish=false --output bin\release\netcoreapp2.0\win10-x64\Unlinked
%__dotnet2% publish -c release -r win10-x64 --output bin\release\netcoreapp2.0\win10-x64\Linked
if errorlevel 1 set ExitCode=1 
popd
exit /b

:WebAPI
echo Build ** WebAPI **
pushd %LinkBenchRoot%\WebAPI
%__dotnet2% restore -r win10-x64
%__dotnet2% publish -c release -r win10-x64 /p:LinkDuringPublish=false --output bin\release\netcoreapp2.0\win10-x64\unlinked
%__dotnet2% publish -c release -r win10-x64 --output bin\release\netcoreapp2.0\win10-x64\linked
if errorlevel 1 set ExitCode=1 
popd
exit /b

:MusicStore
echo Build ** MusicStore **
pushd %LinkBenchRoot%\JitBench\src\MusicStore
copy %AssetDir%\MusicStore\MusicStoreReflection.xml .
%__dotnet2% restore -r win10-x64 
%__dotnet2% publish -c release -r win10-x64 /p:LinkerRootDescriptors=MusicStoreReflection.xml /p:LinkDuringPublish=false --output bin\release\netcoreapp2.0\win10-x64\unlinked
%__dotnet2% publish -c release -r win10-x64 /p:LinkerRootDescriptors=MusicStoreReflection.xml --output bin\release\netcoreapp2.0\win10-x64\linked
if errorlevel 1 set ExitCode=1 
popd
exit /b

:MusicStore_R2R
REM Since the musicstore benchmark has a workaround to use an old framework (to get non-crossgen'd packages), 
REM we need to run crossgen on these assemblies manually for now. 
REM Even once we have the linker running on R2R assemblies and remove this workaround, 
REM we'll need a way to get the pre-crossgen assemblies for the size comparison. 
REM We need to use it to crossgen the linked assemblies for the size comparison, 
REM since the linker targets don't yet include a way to crossgen the linked assemblies.
echo Build ** MusicStore Ready2Run **
pushd %LinkBenchRoot%\JitBench\src\MusicStore
copy %AssetDir%\MusicStore\Get-Crossgen.ps1
powershell -noprofile -executionPolicy RemoteSigned -file Get-Crossgen.ps1
pushd  bin\release\netcoreapp2.0\win10-x64\
mkdir R2R 2> nul
call :SetupR2R unlinked
if errorlevel 1 set ExitCode=1 
call :SetupR2R linked
if errorlevel 1 set ExitCode=1 
popd
exit /b

:CoreFx
echo Build ** CoreFX **
pushd %LinkBenchRoot%\corefx
set BinPlaceILLinkTrimAssembly=true
call build.cmd -release
if errorlevel 1 set ExitCode=1 
popd
exit /b

:Roslyn
echo Build ** Roslyn **
pushd %LinkBenchRoot%\roslyn

REM Fetch ILLink
if not exist illink mkdir illink
cd illink
copy %AssetDir%\Roslyn\illinkcsproj illink.csproj >nul
%__dotnet1% restore --packages pkg
if errorlevel 1 set ExitCode=1 
set __IlLinkDll=%cd%\pkg\microsoft.netcore.illink\0.1.9-preview\lib\netcoreapp1.1\illink.dll
cd ..

REM Build CscCore
call Restore.cmd
cd src\Compilers\CSharp\CscCore
%__dotnet1% publish -c Release -r win7-x64
if errorlevel 1 set ExitCode=1 
REM Published CscCore to Binaries\Release\Exes\CscCore\win7-x64\publish
cd ..\..\..\..

REM Create Linker Directory
cd Binaries\Release\Exes\CscCore\win7-x64\
mkdir Linked

REM Copy Unmanaged Assets
cd publish
FOR /F "delims=" %%I IN ('DIR /b *') DO (
    %__CORFLAGS% %%I >nul 2> nul
    if errorlevel 1 copy %%I ..\Linked >nul
)
copy *.ni.dll ..\Linked

REM Run Linker
%__dotnet1% %__IlLinkDll% -t -c link -a @%AssetDir%\Roslyn\RoslynRoots.txt -x %AssetDir%\Roslyn\RoslynRoots.xml -l none -out ..\Linked
if errorlevel 1 set ExitCode=1 
popd
exit /b

:SetupR2R
REM Create R2R directory and copy all contents from MSIL to R2R directory
mkdir R2R\%1
xcopy /E /Y /Q %1 R2R\%1
REM Generate Ready2Run images for all MSIL files by running crossgen
pushd R2R\%1
copy ..\..\..\..\..\..\crossgen.exe
FOR /F %%I IN ('dir /b *.dll ^| find /V /I ".ni.dll"  ^| find /V /I "System.Private.CoreLib" ^| find /V /I "mscorlib.dll"') DO (
    REM Don't crossgen Corlib, since the native image already exists.
    REM For all other MSIL files (corflags returns 0), run crossgen
    %__CORFLAGS% %%I >nul 2>nul
    if not errorlevel 1 (
        crossgen.exe /Platform_Assemblies_Paths . %%I >nul 2>nul
        if errorlevel 1 (
            exit /b 1
        )
    )
)
del crossgen.exe

REM Remove the original MSIL files, rename the Ready2Run files .ni.dll --> .dll
FOR /F "delims=" %%I IN ('dir /b *.dll') DO (
    if exist %%~nI.ni.dll (
        del %%I 
        ren %%~nI.ni.dll %%I
    )
)
popd
exit /b 0
