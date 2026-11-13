// Fuzzes the arithmetic bytecode parser (Program::parse -> Instruction::parse), the format of
// Programs/Bytecode/*.bc that every MP-SPDZ virtual machine loads.
#include "Processor/Program.h"
#include "Processor/Instruction.h"
#include "Tools/Exceptions.h"
#include "Processor/OnlineOptions.h"

#include <cstdint>
#include <exception>
#include <sstream>
#include <string>

// The project's own embedding switch (-DTHROW_EXCEPTIONS): exit_error() throws instead of exit(1).
extern "C" int LLVMFuzzerInitialize(int*, char***)
{
    OnlineOptions::singleton.options.push_back("throw_exceptions");
    return 0;
}

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size)
{
    std::istringstream in(std::string(reinterpret_cast<const char*>(data), size));
    Program program(3);
    try
    {
        program.parse(in);
    }
    catch (std::exception&)
    {
        return -1;
    }
    return 0;
}
