package io.geordi.demo.downstream;

import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/downstream")
class DownstreamDemoController {

    @GetMapping("/respond")
    String respond() {
        return "downstream-ok";
    }
}
