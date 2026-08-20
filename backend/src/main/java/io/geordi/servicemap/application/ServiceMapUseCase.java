package io.geordi.servicemap.application;

import io.geordi.servicemap.domain.ServiceMapResult;

public interface ServiceMapUseCase {

    ServiceMapResult query(ServiceMapQuery query);
}
