// Fuzzes the binary-circuit bytecode parser (GC::Program::parse -> GC::Instruction::parse).
#include "GC/Program.h"
#include "GC/Program.hpp"
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
    GC::Program program;
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
