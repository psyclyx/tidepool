# Zig package dependencies for tidepool
# Hand-written because zon2nix cannot handle the new Zig hash format.
# Includes both direct dependencies and their transitive non-lazy deps.

{
  linkFarm,
  fetchgit,
}:

linkFarm "zig-packages" [
  # --- Direct dependencies ---

  # zig-janet (Janet language embedded via Zig)
  {
    name = "janet-1.40.1-3XUN8cVGAAA7Os-UamOhi0sYVRqN-slGltgD5Jwwwfdk";
    path = fetchgit {
      url = "https://codeberg.org/ifreund/zig-janet";
      rev = "977e2777b9f0f6fd3531bec3c96c7073b690cbe3";
      hash = "sha256-mKkQziZ6Cpyy9TKcCIB/9PPqRwHP8EVNWdpQwfLWCis=";
    };
  }
  # janet-wayland (Janet bindings for libwayland)
  {
    name = "N-V-__8AAPOoAACNhl0Pd9muOFuvch4kljaImdQiU6FPr9tY";
    path = fetchgit {
      url = "https://codeberg.org/ifreund/janet-wayland";
      rev = "c118af389f43ac853c5189db4fd5cc430c7a3370";
      hash = "sha256-hoQy1uMFeM5Jmh3ZOfnMr88iSBBdJ9PObLg7baw7TNY=";
    };
  }
  # wayland-build.zig (Zig build for wayland)
  {
    name = "wayland-1.24.0-3-dxEBa1pmAABlHkqXCGmZ4r9c_N8fhAXculLHBbO2pRRT";
    path = fetchgit {
      url = "https://github.com/ifreund/wayland-build.zig";
      rev = "8c7f2c42ab0e4c16853d03914ce1f3259cda40db";
      hash = "sha256-3rQYOzTE7zX4PEOA3/6FbhTQUhP4PWPUUVN7Y7GDVAc=";
    };
  }
  # libxkbcommon (Zig build for xkbcommon)
  {
    name = "libxkbcommon-1.11.0-1-93LaF6pwAgDFoaLfOkR8ioG4RVcDHbBhsDmC_rYwyOEG";
    path = fetchgit {
      url = "https://github.com/allyourcodebase/libxkbcommon.git";
      rev = "809157d5118909298f3e086fa8d8103198e938fd";
      hash = "sha256-MY01xZm148gg0WosOgVQz5vEAyzUq6UHgTf6uv1u+yw=";
    };
  }
  # janet-xkbcommon (Janet bindings for xkbcommon)
  {
    name = "N-V-__8AAGELAABqy7_LKHe7k7pcmtqO8MJth7xoJZSYvriG";
    path = fetchgit {
      url = "https://codeberg.org/ifreund/janet-xkbcommon";
      rev = "bdd15cd20329078e47abb30bddddfb7b28f52f66";
      hash = "sha256-G3Ds9cffh+dNlHTLfJEBfb5JcMJI42thMVcV/HooBHs=";
    };
  }
  # spork (Janet standard library)
  {
    name = "N-V-__8AAA3IEACRX8ha9Z5HVJLPzBt9S6Kt7oNfQsWh5vUN";
    path = fetchgit {
      url = "https://github.com/janet-lang/spork";
      rev = "4224d5678ec8bb8777a9075030cf38da52f2d70a";
      hash = "sha256-nZUcK1woCQ+t/Qal/zg0Ok7B5q5RWfe6bflEzfsZIsA=";
    };
  }
  # lemongrass (Janet library)
  {
    name = "N-V-__8AAPMqAQCbXJ9KGZ7pEepOFcJFiLb-PW0LlAOhlgtd";
    path = fetchgit {
      url = "https://github.com/pyrmont/lemongrass";
      rev = "906974b82ba06ed421e0c8cd9a56c6ddc4ca6820";
      hash = "sha256-OUqK57EYh6McnxnbvqoPm92eBMYM5iNaPuN6R0yZHA4=";
    };
  }
  # wayland-protocols
  {
    name = "N-V-__8AAFdWDwA0ktbNUi9pFBHCRN4weXIgIfCrVjfGxqgA";
    path = fetchgit {
      url = "https://gitlab.freedesktop.org/wayland/wayland-protocols.git";
      rev = "88223018d1b578d0d8869866da66d9608e05f928";
      hash = "sha256-vD7Nj9iLeS52Et3gcX1m9Zmp05A+VV3J3hkPcM11YEQ=";
    };
  }

  # --- Transitive dependencies ---

  # janet upstream source (dep of zig-janet)
  {
    name = "N-V-__8AAIEhIgBR5OJUsRfe9z01OzwIngIwNeZy1NBuBEoc";
    path = fetchgit {
      url = "https://github.com/janet-lang/janet";
      rev = "1449ad8b31947999b2b6887fe633883106e5e65c";
      hash = "sha256-BV5hVg85QgN8DXiMF2kA3IQNuvWjcsyciiuQP5+c+7c=";
    };
  }
  # wayland upstream source (dep of wayland-build.zig)
  {
    name = "N-V-__8AAEZXGQD2FnVezv2mY8V4aYW9j-JDCLw6vDmFFqze";
    path = fetchgit {
      url = "https://gitlab.freedesktop.org/wayland/wayland.git";
      rev = "99638501a1314e68c79176fa2cafa3bbe6cf55ea";
      hash = "sha256-2Tz/Owuc8gBHg7CSd4wq+mvowsjm0nbLnasyabVslGg=";
    };
  }
  # libxkbcommon upstream source (dep of allyourcodebase/libxkbcommon)
  {
    name = "N-V-__8AAFRAZAD02nId1w02lyWXmN-hvo873BSh9wZDxjSN";
    path = fetchgit {
      url = "https://github.com/xkbcommon/libxkbcommon.git";
      rev = "0f9cefb1fedb23433666fa5d9045e48ff030c006";
      hash = "sha256-IV1dgGM8z44OQCQYQ5PiUUw/zAvG5IIxiBywYVw2ius=";
    };
  }
]
