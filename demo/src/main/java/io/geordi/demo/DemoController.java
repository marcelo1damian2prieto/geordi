package io.geordi.demo;

import org.springframework.http.HttpStatus;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.server.ResponseStatusException;

@RestController
@RequestMapping("/demo")
class DemoController {

    @GetMapping("/success")
    String success() {
        return "ok";
    }

    @GetMapping("/error")
    String error() {
        throw new ResponseStatusException(HttpStatus.INTERNAL_SERVER_ERROR, "controlled demo error");
    }

    @GetMapping("/slow")
    String slow() throws InterruptedException {
        Thread.sleep(150);
        return "slow";
    }

    @GetMapping("/cpu")
    String cpu() {
        long accumulator = 0;
        for (int index = 0; index < 250_000; index++) {
            accumulator += (long) index * index;
        }
        return Long.toString(accumulator);
    }
}
