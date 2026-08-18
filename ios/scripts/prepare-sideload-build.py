#!/usr/bin/env python3
"""CI helper: drop the Live Activity extension so an unsigned IPA can be sideloaded."""
from pathlib import Path

pbx = Path("ios/GuolemeAI/GuolemeAI.xcodeproj/project.pbxproj")
text = pbx.read_text(encoding="utf-8")
text = text.replace(
    "\t\t\t\tH00000000000000000000001 /* Copy Shared Prompts */,\n\t\t\t\tE00000000000000000000001 /* Embed Foundation Extensions */,\n",
    "\t\t\t\tH00000000000000000000001 /* Copy Shared Prompts */,\n",
)
text = text.replace(
    "\t\t\t\tD00000000000000000000001 /* PBXTargetDependency */,\n",
    "",
)
pbx.write_text(text, encoding="utf-8")
print("stripped Live Activity embed for sideload IPA")
