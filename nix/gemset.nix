{
  adwaita = {
    dependencies = ["gtk4" "rake"];
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "1fq30qnd7y803wnnpkx1mqa2prd25w1p40w5zc8iq8vayc3cmfy6";
      type = "gem";
    };
    version = "4.4.0";
  };
  atk = {
    dependencies = ["glib2" "rake"];
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "0h9pz8i1pia9fydfwj4aiz9jcfvjkswvvkrncprd8cgr7cj23nj3";
      type = "gem";
    };
    version = "4.4.0";
  };
  cairo = {
    dependencies = ["pkg-config" "red-colors"];
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "08x6f2idyfnylq0b66mqi8lf5mjvff2y2q02n5hq0x4i3ha5cwz5";
      type = "gem";
    };
    version = "1.18.5";
  };
  cairo-gobject = {
    dependencies = ["cairo" "glib2"];
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "1f7r14rad8vashbjvwzg7c1d2kfj2z2hh2ljy2y110k836vwcwwz";
      type = "gem";
    };
    version = "4.4.0";
  };
  fiddle = {
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "1vifygrkw22gcd4wzh8gc4pv6h1zpk6kll6mmprrf5174wvfxa3z";
      type = "gem";
    };
    version = "1.1.8";
  };
  gdk4 = {
    dependencies = ["cairo-gobject" "gdk_pixbuf2" "pango" "rake"];
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "1xifafpiw4ldbvacxqq38403dywwvdhxih2w9x4f3rapaix3s82h";
      type = "gem";
    };
    version = "4.4.0";
  };
  gdk_pixbuf2 = {
    dependencies = ["gio2" "rake"];
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "011jdpvpbclx319mc7czxbkdk9z8wg5bjws5p4n26hdg43h5bajq";
      type = "gem";
    };
    version = "4.4.0";
  };
  gem_kit = {
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "0dx9w041lqzr4jd0m9as0v5v6n3fj2hcg74p2gyswr2y2a6zc5v9";
      type = "gem";
    };
    version = "0.2.0";
  };
  gio2 = {
    dependencies = ["fiddle" "gobject-introspection"];
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "0g5nsicd09vd323mpjdg3q8c7cavq00c0wi8j6bfywxmvr7dxzxv";
      type = "gem";
    };
    version = "4.4.0";
  };
  glib2 = {
    dependencies = ["native-package-installer" "pkg-config"];
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "0yxjj9ab71yhn7syzfbsk74vzzb1xbchpb0yl9dpcz856c21raqc";
      type = "gem";
    };
    version = "4.4.0";
  };
  gobject-introspection = {
    dependencies = ["glib2"];
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "032jh10zpwfbzvfpc6mgc7nfw2a7nn84sww1g3c0ma25v4fyhky9";
      type = "gem";
    };
    version = "4.4.0";
  };
  graphene1 = {
    dependencies = ["gobject-introspection"];
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "11xijbw93vsm1nam92f63nlx7bs8ph5jvyvh4hfma1d45amxx9sf";
      type = "gem";
    };
    version = "4.4.0";
  };
  gsk4 = {
    dependencies = ["gdk4" "graphene1"];
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "18zjnwd2d0k8iah7szhqm90hzb24v5hhvm86lhjzv0mvhq1dyi0k";
      type = "gem";
    };
    version = "4.4.0";
  };
  gtk4 = {
    dependencies = ["atk" "gdk4" "gsk4"];
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "0pbica72ziw9ip5w8465va5rlvcx44hplh3x0pyp83f41r04rxbc";
      type = "gem";
    };
    version = "4.4.0";
  };
  gtksourceview5 = {
    dependencies = ["gtk4" "rake"];
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "0ilk7b4lhfibqcfmiz36x8qqcqf5qd71bc460iv9ix37yn306s99";
      type = "gem";
    };
    version = "4.4.0";
  };
  json = {
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "1n1v9rhb19cnf1a89s6yvvhw394jy8qnqx9sg8bn12g5zpwcrrrw";
      type = "gem";
    };
    version = "3.1.0";
  };
  libspelling = {
    dependencies = ["gem_kit" "gobject-introspection"];
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "06fk678sm6ylgf11pdcbkb323m869bwhibap9lp8g9ncg2fsvhsl";
      type = "gem";
    };
    version = "1.0.0";
  };
  matrix = {
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "0nscas3a4mmrp1rc07cdjlbbpb2rydkindmbj3v3z5y1viyspmd0";
      type = "gem";
    };
    version = "0.4.3";
  };
  native-package-installer = {
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "0bvr9q7qwbmg9jfg85r1i5l7d0yxlgp0l2jg62j921vm49mipd7v";
      type = "gem";
    };
    version = "1.1.9";
  };
  pango = {
    dependencies = ["cairo-gobject" "gobject-introspection"];
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "155iqw9c0ljrpymmzcifvryj8w4mkc64r1ys4gdjiafz149cinay";
      type = "gem";
    };
    version = "4.4.0";
  };
  pkg-config = {
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "02q7w7qp46gd1p2nxh5lwvxkmivjhl4yk90v1nk5bnlmhpvyy584";
      type = "gem";
    };
    version = "1.6.7";
  };
  rake = {
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "009p524zl0p0kfa65nii8wdmaigkmawv9pbvlcffky7islmmp0nb";
      type = "gem";
    };
    version = "13.4.2";
  };
  red-colors = {
    dependencies = ["json" "matrix"];
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "06ddk6dr7h3w3qvz18795md3nbh2c52bm1bl8vz3ac44s41zccqa";
      type = "gem";
    };
    version = "0.5.0";
  };
  soup3 = {
    dependencies = ["gem_kit" "gobject-introspection"];
    groups = ["default"];
    platforms = [];
    source = {
      remotes = ["https://rubygems.org"];
      sha256 = "1n48kwwgvra4055di6cz1xw2izvn3gajalc8wprbbis4a96dyz2n";
      type = "gem";
    };
    version = "1.0.0";
  };
}
