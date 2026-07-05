// somebar config.hpp — matches dwm/dwl theme
#pragma once
#include "common.hpp"

#define WTYPE "/usr/bin/wtype"
#define MODKEY "logo"
constexpr bool topbar = true;

constexpr int paddingX = 10;
constexpr int paddingY = 3;

constexpr const char* font = "Berkeley Mono 16";

constexpr ColorScheme colorInactive = {Color(0xbb, 0xbb, 0xbb), Color(0x00, 0x00, 0x00)};
constexpr ColorScheme colorActive   = {Color(0xff, 0xff, 0xff), Color(0x00, 0x00, 0x00)};
constexpr const char* termcmd[] = {"foot", nullptr};

static std::vector<std::string> tagNames = {
	"1", "2", "3",
	"4", "5", "6",
	"7", "8", "9",
};

constexpr Button buttons[] = {
	{ ClkTagBar,      BTN_LEFT,   view,       {0} },
	{ ClkTagBar,      BTN_RIGHT,  tag,        {0} },
	{ ClkStatusText,  BTN_RIGHT,  spawn,      {.v = termcmd} },
};
