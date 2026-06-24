/*
 * Copyright 2002-2025 the original author or authors.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      https://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package org.springframework.web.method;

import java.lang.annotation.Annotation;
import java.lang.annotation.Retention;
import java.lang.annotation.RetentionPolicy;
import java.lang.reflect.Method;

import org.junit.jupiter.api.Test;

import org.springframework.core.MethodParameter;
import org.springframework.util.ClassUtils;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * Tests for {@link HandlerMethod}.
 *
 * @author Sam Brannen
 */
class HandlerMethodTests {

	@Test
	void parameterAnnotationFromInterfaceWithUnresolvedGenericsInTypeHierarchy() {
		// The method is GenericAbstractSuperclass.processOneAndTwo(Long, C),
		// where 'C' is unresolved. isOverrideFor() must match it against the
		// interface method so that @Validated on parameter B is discovered.
		Method method = ClassUtils.getMethod(GenericInterfaceImpl.class, "processOneAndTwo", Long.class, Object.class);
		HandlerMethod handlerMethod = new HandlerMethod(new GenericInterfaceImpl(), method);
		MethodParameter param = handlerMethod.getMethodParameters()[1];
		Annotation[] annotations = param.getParameterAnnotations();
		assertThat(annotations).extracting(Annotation::annotationType)
				.contains(Validated.class);
	}


	@Retention(RetentionPolicy.RUNTIME)
	@interface Validated {
	}

	interface GenericInterface<A, B> {

		void processOneAndTwo(A value1, @Validated B value2);
	}

	abstract static class GenericAbstractSuperclass<C> implements GenericInterface<Long, C> {

		@Override
		public void processOneAndTwo(Long value1, C value2) {
		}
	}

	static class GenericInterfaceImpl extends GenericAbstractSuperclass<String> {
		// The compiler does not require us to declare a concrete
		// processOneAndTwo(Long, String) method, and we intentionally
		// do not declare one here.
	}

}
