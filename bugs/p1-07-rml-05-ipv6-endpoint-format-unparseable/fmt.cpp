// Prints what the emulator's endpoint_to_string() (ss << tcp::endpoint) yields for an IPv6 endpoint.
// No socket is created, so this works on hosts without IPv6 support.
#include <boost/asio/ip/tcp.hpp>
#include <iostream>
#include <sstream>
int main() {
    boost::asio::ip::tcp::endpoint ep{boost::asio::ip::make_address("::1"), 41234};
    std::ostringstream ss; ss << ep; std::cout << ss.str() << "\n";
}
