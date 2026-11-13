// Fuzzes the deserialisers that parse protocol messages received from other parties: octetStream
// primitives (bigint, string, bytes, bits), field/ring elements and shares, and octetStream::input.
// Byte 0 picks the decoder, the rest is the message.
#include "Tools/octetStream.h"
#include "Tools/Exceptions.h"
#include "Math/bigint.h"
#include "Math/gfp.hpp"
#include "Math/gf2n.h"
#include "Math/Z2k.hpp"
#include "Math/Integer.h"
#include "Protocols/Share.hpp"
#include "Protocols/SemiShare.h"

#include <cstdint>
#include <exception>
#include <sstream>
#include <string>

typedef gfp_<0, 2> gfp2;

extern "C" int LLVMFuzzerInitialize(int*, char***)
{
    gfp2::init_default(128);
    gf2n_long::init_field(128);
    return 0;
}

template<class T>
static void unpack_all(octetStream& os)
{
    while (os.left() > 0)
    {
        T x;
        x.unpack(os);
    }
}

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size)
{
    if (size < 1)
        return -1;
    int mode = data[0] % 12;
    octetStream os(size - 1, data + 1);
    try
    {
        switch (mode)
        {
        case 0:
        {
            bigint x;
            os.get(x);
            break;
        }
        case 1:
        {
            string s;
            os.get(s);
            break;
        }
        case 2:
        {
            size_t n = os.get_int(1);
            vector<octet> buf(n);
            os.get_bytes(buf.data(), n);
            break;
        }
        case 3:
            unpack_all<gfp2>(os);
            break;
        case 4:
            unpack_all<gf2n_long>(os);
            break;
        case 5:
            unpack_all<Z2<64>>(os);
            break;
        case 6:
            unpack_all<SignedZ2<128>>(os);
            break;
        case 7:
            unpack_all<Share<gfp2>>(os);
            break;
        case 8:
            unpack_all<Share<gf2n_long>>(os);
            break;
        case 9:
            unpack_all<Integer>(os);
            break;
        case 10:
        {
            while (os.left() > 0)
                os.get_bits(1 + os.get_int(1) % 8);
            break;
        }
        case 11:
        {
            std::istringstream in(std::string(reinterpret_cast<const char*>(data + 1), size - 1));
            octetStream input;
            input.input(in);
            break;
        }
        }
    }
    catch (std::exception&)
    {
        return -1;
    }
    return 0;
}
